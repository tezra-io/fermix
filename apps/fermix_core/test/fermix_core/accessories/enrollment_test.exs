defmodule FermixCore.Accessories.EnrollmentTest do
  # Pairing over the cable the owner selected (M91 §07, D11, D14; PROTOCOL.md,
  # *Enrollment*): the host commits to its nonce before the accessory offers
  # its own and reveals it after, one attempt, two minutes until the commit,
  # at most three comparison rounds, and a record only for a key whose code the
  # owner confirmed and that signed the transcript. Time is injected monotonic
  # milliseconds.
  use ExUnit.Case, async: true

  alias FermixCore.Accessories.Enrollment
  alias FermixCore.Accessories.HostKey
  alias FermixCore.Accessories.P256
  alias FermixCore.Accessories.Transcript

  @now 5_000_000

  setup do
    {:ok, host} = HostKey.from_private(elem(P256.generate(), 1))
    {accessory_pk, accessory_private} = P256.generate()
    %{host: host, pk: accessory_pk, private: accessory_private}
  end

  defp offer(enrollment, pk, nonce \\ :crypto.strong_rand_bytes(32)) do
    %{
      type: "enroll.offer",
      gen: 1,
      attempt: enrollment.attempt,
      round: enrollment.round,
      accessory_pk: pk,
      accessory_nonce: nonce
    }
  end

  defp confirmed(enrollment, private) do
    %{
      type: "enroll.confirmed",
      gen: 1,
      attempt: enrollment.attempt,
      round: enrollment.round,
      sig: P256.sign(enrollment.transcript, private)
    }
  end

  defp revealed(enrollment, pk, now) do
    {:ok, enrollment} = Enrollment.offer(enrollment, offer(enrollment, pk), now)
    {:ok, _reveal, enrollment} = Enrollment.reveal_message(enrollment, 1)
    enrollment
  end

  defp revealed(host, pk), do: host |> Enrollment.open(@now) |> revealed(pk, @now)

  defp committing(host, pk, private) do
    enrollment = revealed(host, pk)

    {:ok, enrollment} =
      Enrollment.accessory_confirmed(enrollment, confirmed(enrollment, private), @now)

    {:ok, enrollment} = Enrollment.owner_confirmed(enrollment, @now)
    {:ok, _commit, enrollment} = Enrollment.commit_message(enrollment, host, 1)
    enrollment
  end

  test "an owner-confirmed pairing commits with the host's signature and yields the record's key",
       %{host: host, pk: pk, private: private} do
    enrollment = Enrollment.open(host, @now)
    begin = Enrollment.begin_message(enrollment, 1)

    assert %{type: "enroll.begin", gen: 1, round: 1, host_pk: host_pk, host_id: host_id} = begin
    assert host_pk == host.public and host_id == host.id
    assert begin.attempt =~ ~r/\A[0-9a-f]{32}\z/

    nonce = :crypto.strong_rand_bytes(32)

    assert {:ok, enrollment} =
             Enrollment.offer(enrollment, offer(enrollment, pk, nonce), @now + 10)

    assert {:ok, reveal, enrollment} = Enrollment.reveal_message(enrollment, 1)
    assert %{type: "enroll.reveal", attempt: attempt, round: 1, host_nonce: host_nonce} = reveal
    assert attempt == enrollment.attempt
    assert :crypto.hash(:sha256, host_nonce) == begin.host_commit

    transcript =
      Transcript.enroll(%{
        host_pk: host.public,
        accessory_pk: pk,
        host_nonce: host_nonce,
        accessory_nonce: nonce
      })

    assert Enrollment.compare_code(enrollment) == Transcript.compare_code(transcript)
    assert {:error, :not_confirmed} = Enrollment.commit_message(enrollment, host, 1)

    assert {:ok, enrollment} =
             Enrollment.accessory_confirmed(enrollment, confirmed(enrollment, private), @now + 20)

    assert {:error, :not_confirmed} = Enrollment.commit_message(enrollment, host, 1)
    assert {:ok, enrollment} = Enrollment.owner_confirmed(enrollment, @now + 30)

    assert {:ok, commit, enrollment} = Enrollment.commit_message(enrollment, host, 1)
    assert %{type: "enroll.commit", attempt: ^attempt, round: 1} = commit
    assert P256.verify(transcript, commit.host_sig, host.public)

    done = %{type: "enroll.done", gen: 1, attempt: attempt, accessory_id: P256.id(pk)}

    assert {:ok, %{accessory_id: id, accessory_pk: ^pk}, enrollment} =
             Enrollment.done(enrollment, done, @now + 40)

    assert id == P256.id(pk)
    assert enrollment.phase == :done
  end

  test "enroll.begin commits to the host nonce and never carries it", %{host: host} do
    enrollment = Enrollment.open(host, @now)
    begin = Enrollment.begin_message(enrollment, 1)

    refute Map.has_key?(begin, :host_nonce)
    assert begin.host_commit == :crypto.hash(:sha256, enrollment.host_nonce)
  end

  test "the nonce is revealed only after the accessory offered its own, and nothing is shown before",
       %{host: host, pk: pk, private: private} do
    enrollment = Enrollment.open(host, @now)
    assert {:error, :out_of_order} = Enrollment.reveal_message(enrollment, 1)

    {:ok, offered} = Enrollment.offer(enrollment, offer(enrollment, pk), @now)
    assert Enrollment.compare_code(offered) == nil

    assert {:ignored, :out_of_order, ^offered} =
             Enrollment.accessory_confirmed(offered, confirmed(offered, private), @now)

    assert {:ignored, :out_of_order, ^offered} = Enrollment.owner_confirmed(offered, @now)
    assert {:ignored, :out_of_order, ^offered} = Enrollment.mismatch(offered, @now)

    {:ok, _reveal, revealed} = Enrollment.reveal_message(offered, 1)
    assert Enrollment.compare_code(revealed) =~ ~r/\A[0-9]{6}\z/
    assert {:error, :out_of_order} = Enrollment.reveal_message(revealed, 1)
  end

  test "the owner may confirm before the accessory does", %{host: host, pk: pk, private: private} do
    enrollment = revealed(host, pk)
    assert {:ok, enrollment} = Enrollment.owner_confirmed(enrollment, @now)

    assert {:ok, enrollment} =
             Enrollment.accessory_confirmed(enrollment, confirmed(enrollment, private), @now)

    assert {:ok, _commit, _enrollment} = Enrollment.commit_message(enrollment, host, 1)
  end

  test "every attempt has its own ID, and a message for another attempt or round is ignored",
       %{host: host, pk: pk} do
    first = Enrollment.open(host, @now)
    second = Enrollment.open(host, @now)
    refute first.attempt == second.attempt

    assert {:ignored, :stale_attempt, ^first} = Enrollment.offer(first, offer(second, pk), @now)

    assert {:ignored, :stale_round, ^first} =
             Enrollment.offer(first, %{offer(first, pk) | round: 2}, @now)
  end

  test "the attempt closes two minutes after it opened", %{host: host, pk: pk} do
    enrollment = Enrollment.open(host, @now)
    late = @now + Enrollment.window_ms()

    assert {:ok, _} = Enrollment.offer(enrollment, offer(enrollment, pk), late - 1)
    assert {:closed, :expired, closed} = Enrollment.offer(enrollment, offer(enrollment, pk), late)
    assert closed.phase == :closed
    assert Enrollment.expired?(enrollment, late)
    assert {:ignored, :closed, ^closed} = Enrollment.owner_confirmed(closed, late)
  end

  test "once the commit is sent the window no longer runs: the accessory may be burning its key",
       %{host: host, pk: pk, private: private} do
    enrollment = committing(host, pk, private)
    done = %{type: "enroll.done", gen: 1, attempt: enrollment.attempt, accessory_id: P256.id(pk)}

    assert {:ok, %{accessory_id: _id}, _enrollment} =
             Enrollment.done(enrollment, done, @now + Enrollment.window_ms() + 60_000)
  end

  test "each failed comparison starts a new round with a new commitment and code, and the third closes",
       %{host: host, pk: pk} do
    enrollment = Enrollment.open(host, @now)
    first_commit = Enrollment.begin_message(enrollment, 1).host_commit
    enrollment = revealed(enrollment, pk, @now)
    first_code = Enrollment.compare_code(enrollment)

    assert {:ok, enrollment} = Enrollment.mismatch(enrollment, @now + 1)
    assert enrollment.round == 2 and enrollment.phase == :begun
    assert Enrollment.compare_code(enrollment) == nil
    assert %{round: 2, host_commit: second_commit} = Enrollment.begin_message(enrollment, 1)
    refute second_commit == first_commit

    enrollment = revealed(enrollment, pk, @now + 2)
    refute Enrollment.compare_code(enrollment) == first_code
    assert {:ok, enrollment} = Enrollment.mismatch(enrollment, @now + 3)
    assert enrollment.round == 3

    enrollment = revealed(enrollment, pk, @now + 4)
    assert {:closed, :mismatch_limit, closed} = Enrollment.mismatch(enrollment, @now + 5)
    assert closed.phase == :closed
  end

  test "a confirmation that does not prove the offered key closes the attempt", %{
    host: host,
    pk: pk
  } do
    enrollment = revealed(host, pk)
    {_other_pk, stranger} = P256.generate()

    assert {:closed, :invalid_offer, _} =
             Enrollment.accessory_confirmed(enrollment, confirmed(enrollment, stranger), @now)
  end

  test "an offer of the host's own key or of a point off the curve closes the attempt", %{
    host: host
  } do
    enrollment = Enrollment.open(host, @now)
    off_curve = <<4, 1::256, 2::256>>

    assert {:closed, :invalid_offer, _} =
             Enrollment.offer(enrollment, offer(enrollment, host.public), @now)

    assert {:closed, :invalid_offer, _} =
             Enrollment.offer(enrollment, offer(enrollment, off_curve), @now)
  end

  test "a done naming another accessory ID closes the attempt", %{
    host: host,
    pk: pk,
    private: private
  } do
    enrollment = committing(host, pk, private)

    wrong = %{
      type: "enroll.done",
      gen: 1,
      attempt: enrollment.attempt,
      accessory_id: String.duplicate("0", 64)
    }

    assert {:closed, :invalid_offer, _} = Enrollment.done(enrollment, wrong, @now)
  end

  test "a message out of order is ignored, never acted on", %{host: host, pk: pk} do
    enrollment = Enrollment.open(host, @now)
    done = %{type: "enroll.done", gen: 1, attempt: enrollment.attempt, accessory_id: P256.id(pk)}

    assert {:ignored, :out_of_order, ^enrollment} = Enrollment.done(enrollment, done, @now)
    assert {:ignored, :out_of_order, ^enrollment} = Enrollment.owner_confirmed(enrollment, @now)
    assert {:ignored, :out_of_order, ^enrollment} = Enrollment.mismatch(enrollment, @now)

    revealed = revealed(host, pk)

    assert {:ignored, :out_of_order, ^revealed} =
             Enrollment.offer(revealed, offer(revealed, pk), @now)
  end

  test "a cancelled attempt is closed with its reason", %{host: host} do
    enrollment = host |> Enrollment.open(@now) |> Enrollment.cancel(:owner)
    assert enrollment.phase == :closed and enrollment.closed_reason == :owner
  end
end
