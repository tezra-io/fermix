defmodule FermixCore.Accessories.Enrollment do
  @moduledoc """
  One pairing attempt over the cable the owner selected (M91 §07, D11, D14;
  `priv/accessory/PROTOCOL.md`, *Enrollment*), as a pure state value the link
  process holds; it holds at most one at a time.

  Phases: `:begun` (an `enroll.begin` is out, carrying only the SHA-256 of
  the host nonce) → `:offered` (the accessory sent its key and nonce) →
  `:revealed` (the host's `enroll.reveal` is out, so both screens show the
  compare code; waiting for the accessory's `enroll.confirmed`, which proves
  it holds the offered key, and for the owner's confirmation in the app, in
  either order) → `:committing` (the host's `enroll.commit` is out) → `:done`
  on `enroll.done`, when the caller writes the record. `:closed` ends it with
  an `enroll.cancel` reason.

  The host commits to its nonce before it sees the accessory's and reveals it
  only after, so neither nonce can be chosen knowing the other: something
  between the two ends that substitutes keys gets codes that agree by chance,
  one in a million a round.

  Bounds: 120 seconds from the attempt's opening until the commit, and at
  most three comparison rounds: a failed comparison starts the next round with
  a new host nonce, so each round shows a new code, and the third closes the
  attempt (`mismatch_limit`). Once the commit is out the window stops: the
  accessory may be burning its key-protection eFuse, and the link's own
  bounds end the attempt if the accessory goes.

  Every step answers one of three ways: `{:ok, enrollment}`; `{:ignored,
  reason, enrollment}` for a message of another attempt or round, or out of
  order, which is dropped and changes nothing; `{:closed, reason,
  enrollment}`, which ends the attempt and is told to the accessory as
  `enroll.cancel {reason}`. Time is the caller's monotonic milliseconds.
  """

  alias FermixCore.Accessories.HostKey
  alias FermixCore.Accessories.P256
  alias FermixCore.Accessories.Transcript

  @window_ms 120_000
  @max_rounds 3

  @enforce_keys [:attempt, :host_pk, :host_id, :host_nonce, :deadline_ms]
  defstruct @enforce_keys ++
              [
                round: 1,
                phase: :begun,
                accessory_pk: nil,
                accessory_nonce: nil,
                transcript: nil,
                accessory_confirmed?: false,
                owner_confirmed?: false,
                closed_reason: nil
              ]

  @type phase :: :begun | :offered | :revealed | :committing | :done | :closed
  @type close_reason ::
          :owner | :expired | :mismatch_limit | :invalid_offer | :invalid_reveal | :link_reset
  @type ignore_reason :: :stale_attempt | :stale_round | :out_of_order | :closed
  @type t :: %__MODULE__{
          attempt: String.t(),
          host_pk: P256.public_key(),
          host_id: String.t(),
          host_nonce: <<_::256>>,
          deadline_ms: integer(),
          round: 1..3,
          phase: phase(),
          accessory_pk: P256.public_key() | nil,
          accessory_nonce: <<_::256>> | nil,
          transcript: binary() | nil,
          accessory_confirmed?: boolean(),
          owner_confirmed?: boolean(),
          closed_reason: close_reason() | nil
        }
  @type step :: {:ok, t()} | {:ignored, ignore_reason(), t()} | {:closed, close_reason(), t()}

  @doc "How long an attempt stays open."
  @spec window_ms() :: pos_integer()
  def window_ms, do: @window_ms

  @doc "A new attempt, opened at `now_ms`, with its own random ID and host nonce."
  @spec open(HostKey.t(), integer()) :: t()
  def open(%HostKey{} = host, now_ms) when is_integer(now_ms) do
    %__MODULE__{
      attempt: Base.encode16(:crypto.strong_rand_bytes(16), case: :lower),
      host_pk: host.public,
      host_id: host.id,
      host_nonce: :crypto.strong_rand_bytes(32),
      deadline_ms: now_ms + @window_ms
    }
  end

  @doc """
  The `enroll.begin` of the current round, for `Control.encode(:host, _)`: it
  carries the host nonce's SHA-256, never the nonce.
  """
  @spec begin_message(t(), pos_integer()) :: map()
  def begin_message(%__MODULE__{phase: :begun} = e, gen) when gen in 1..4_294_967_295 do
    %{
      type: "enroll.begin",
      gen: gen,
      attempt: e.attempt,
      round: e.round,
      host_pk: e.host_pk,
      host_id: e.host_id,
      host_commit: :crypto.hash(:sha256, e.host_nonce)
    }
  end

  @doc """
  The `enroll.reveal` that sends the host nonce, once the accessory has offered
  its own; the accessory checks it against the commitment before it shows a
  code.
  """
  @spec reveal_message(t(), pos_integer()) :: {:ok, map(), t()} | {:error, :out_of_order}
  def reveal_message(%__MODULE__{phase: :offered} = e, gen) when gen in 1..4_294_967_295 do
    message = %{
      type: "enroll.reveal",
      gen: gen,
      attempt: e.attempt,
      round: e.round,
      host_nonce: e.host_nonce
    }

    {:ok, message, %{e | phase: :revealed}}
  end

  def reveal_message(%__MODULE__{}, _gen), do: {:error, :out_of_order}

  @doc "Whether the attempt's two minutes are up."
  @spec expired?(t(), integer()) :: boolean()
  def expired?(%__MODULE__{deadline_ms: deadline}, now_ms) when is_integer(now_ms),
    do: now_ms >= deadline

  @doc "The six-digit compare code both screens show, once the host nonce is revealed."
  @spec compare_code(t()) :: String.t() | nil
  def compare_code(%__MODULE__{phase: phase, transcript: transcript})
      when phase in [:revealed, :committing, :done] and is_binary(transcript),
      do: Transcript.compare_code(transcript)

  def compare_code(%__MODULE__{}), do: nil

  @doc "The accessory's `enroll.offer`: its public key and nonce for this round."
  @spec offer(t(), map(), integer()) :: step()
  def offer(%__MODULE__{} = e, %{type: "enroll.offer"} = message, now_ms) do
    with {:ok, e} <- current(e, message, now_ms, :begun) do
      offered(e, message)
    end
  end

  defp offered(e, %{accessory_pk: pk, accessory_nonce: nonce}) do
    if P256.valid_public_key?(pk) and pk != e.host_pk do
      transcript =
        Transcript.enroll(%{
          host_pk: e.host_pk,
          accessory_pk: pk,
          host_nonce: e.host_nonce,
          accessory_nonce: nonce
        })

      {:ok,
       %{e | phase: :offered, accessory_pk: pk, accessory_nonce: nonce, transcript: transcript}}
    else
      close(e, :invalid_offer)
    end
  end

  @doc "The accessory's `enroll.confirmed`: the owner tapped Matches, and it signs the transcript."
  @spec accessory_confirmed(t(), map(), integer()) :: step()
  def accessory_confirmed(
        %__MODULE__{} = e,
        %{type: "enroll.confirmed", sig: sig} = message,
        now_ms
      ) do
    with {:ok, e} <- current(e, message, now_ms, :revealed) do
      if P256.verify(e.transcript, sig, e.accessory_pk),
        do: {:ok, %{e | accessory_confirmed?: true}},
        else: close(e, :invalid_offer)
    end
  end

  @doc "The owner confirmed in the app that both screens show the same code."
  @spec owner_confirmed(t(), integer()) :: step()
  def owner_confirmed(%__MODULE__{} = e, now_ms) do
    with {:ok, e} <- live(e, now_ms, :revealed), do: {:ok, %{e | owner_confirmed?: true}}
  end

  @doc """
  The owner said the codes differ: the next round, with a new host nonce for a
  new code, or the attempt closed after the third.
  """
  @spec mismatch(t(), integer()) :: step()
  def mismatch(%__MODULE__{} = e, now_ms) do
    with {:ok, e} <- live(e, now_ms, :revealed) do
      if e.round >= @max_rounds, do: close(e, :mismatch_limit), else: {:ok, next_round(e)}
    end
  end

  defp next_round(e) do
    %{
      e
      | round: e.round + 1,
        phase: :begun,
        host_nonce: :crypto.strong_rand_bytes(32),
        accessory_pk: nil,
        accessory_nonce: nil,
        transcript: nil,
        accessory_confirmed?: false,
        owner_confirmed?: false
    }
  end

  @doc "The host's `enroll.commit`, once both the accessory and the owner confirmed."
  @spec commit_message(t(), HostKey.t(), pos_integer()) ::
          {:ok, map(), t()} | {:error, :not_confirmed}
  def commit_message(%__MODULE__{phase: :revealed} = e, %HostKey{public: public} = host, gen)
      when public == e.host_pk and gen in 1..4_294_967_295 do
    if e.accessory_confirmed? and e.owner_confirmed? do
      sig = P256.sign(e.transcript, host.private)

      message = %{
        type: "enroll.commit",
        gen: gen,
        attempt: e.attempt,
        round: e.round,
        host_sig: sig
      }

      {:ok, message, %{e | phase: :committing}}
    else
      {:error, :not_confirmed}
    end
  end

  def commit_message(%__MODULE__{}, %HostKey{}, _gen), do: {:error, :not_confirmed}

  @doc "The accessory's `enroll.done`: what the caller records, once its ID is its key's digest."
  @spec done(t(), map(), integer()) ::
          {:ok, %{accessory_id: String.t(), accessory_pk: P256.public_key()}, t()}
          | {:ignored, ignore_reason(), t()}
          | {:closed, close_reason(), t()}
  def done(%__MODULE__{} = e, %{type: "enroll.done", accessory_id: id} = message, now_ms) do
    with {:ok, e} <- current(e, Map.put(message, :round, e.round), now_ms, :committing) do
      if id == P256.id(e.accessory_pk),
        do: {:ok, %{accessory_id: id, accessory_pk: e.accessory_pk}, %{e | phase: :done}},
        else: close(e, :invalid_offer)
    end
  end

  @doc """
  Closes the attempt: the owner cancelled, the link went, or the accessory
  sent `enroll.cancel` with any of the contract's reasons.
  """
  @spec cancel(t(), close_reason()) :: t()
  def cancel(%__MODULE__{} = e, reason)
      when reason in [
             :owner,
             :expired,
             :mismatch_limit,
             :invalid_offer,
             :invalid_reveal,
             :link_reset
           ],
      do: %{e | phase: :closed, closed_reason: reason}

  # A message must name this attempt and round, arrive in time and in its
  # phase. The window no longer runs once the commit is out.
  defp current(e, %{attempt: attempt, round: round}, now_ms, phase) do
    cond do
      e.phase == :closed -> {:ignored, :closed, e}
      attempt != e.attempt -> {:ignored, :stale_attempt, e}
      round != e.round -> {:ignored, :stale_round, e}
      true -> live(e, now_ms, phase)
    end
  end

  defp live(%__MODULE__{phase: :closed} = e, _now_ms, _phase), do: {:ignored, :closed, e}

  defp live(e, now_ms, phase) do
    cond do
      e.phase != :committing and expired?(e, now_ms) -> close(e, :expired)
      e.phase != phase -> {:ignored, :out_of_order, e}
      true -> {:ok, e}
    end
  end

  defp close(e, reason), do: {:closed, reason, %{e | phase: :closed, closed_reason: reason}}
end
