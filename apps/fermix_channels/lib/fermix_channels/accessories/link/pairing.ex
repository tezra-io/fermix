defmodule FermixChannels.Accessories.Link.Pairing do
  @moduledoc """
  The link's side of one pairing attempt (M91 §07; `priv/accessory/PROTOCOL.md`,
  *Enrollment*), over `FermixCore.Accessories.Enrollment`: each step takes
  the attempt and answers the effects the link carries out, in order, and the
  attempt after them. Pure.

  Effects: `{:send, message}` (a host message, without its `gen`, which the
  link adds), `{:enrolled, %{accessory_id, accessory_pk}}` (write the record),
  and `{:ignored, reason}` (a message of another attempt or round, or out of
  order, dropped and counted). An attempt the steps close is told to the
  accessory as `enroll.cancel {reason}`; closing on USB loss needs no message.

  The host reveals its nonce the moment the accessory's offer is in, so both
  screens show the compare code; it commits only once both the accessory
  (`enroll.confirmed`, which proves it holds the offered key) and the owner
  in the app have confirmed, in either order.
  """

  alias FermixCore.Accessories.Enrollment
  alias FermixCore.Accessories.HostKey

  @cancel_reasons %{
    "owner" => :owner,
    "expired" => :expired,
    "mismatch_limit" => :mismatch_limit,
    "invalid_offer" => :invalid_offer,
    "invalid_reveal" => :invalid_reveal,
    "link_reset" => :link_reset
  }

  @type effect ::
          {:send, map()}
          | {:enrolled, %{accessory_id: String.t(), accessory_pk: binary()}}
          | {:ignored, Enrollment.ignore_reason()}
  @type result :: {[effect()], Enrollment.t()}

  @doc "Opens an attempt and sends its first `enroll.begin`."
  @spec begin(HostKey.t(), pos_integer(), integer()) :: result()
  def begin(%HostKey{} = host, gen, now_ms) do
    enrollment = Enrollment.open(host, now_ms)
    {[{:send, Map.delete(Enrollment.begin_message(enrollment, gen), :gen)}], enrollment}
  end

  @doc "Whether an attempt is still running (neither done nor closed)."
  @spec open?(Enrollment.t() | nil) :: boolean()
  def open?(%Enrollment{phase: phase}), do: phase not in [:done, :closed]
  def open?(nil), do: false

  @doc "One of the accessory's enrollment messages."
  @spec accessory(Enrollment.t(), map(), HostKey.t(), pos_integer(), integer()) :: result()
  def accessory(%Enrollment{} = e, %{type: "enroll.offer"} = message, _host, gen, now_ms),
    do: e |> Enrollment.offer(message, now_ms) |> after_offer(gen)

  def accessory(%Enrollment{} = e, %{type: "enroll.confirmed"} = message, host, gen, now_ms),
    do: e |> Enrollment.accessory_confirmed(message, now_ms) |> then_commit(host, gen)

  def accessory(%Enrollment{} = e, %{type: "enroll.done"} = message, _host, _gen, now_ms) do
    case Enrollment.done(e, message, now_ms) do
      {:ok, enrolled, e} -> {[{:enrolled, enrolled}], e}
      other -> settled(other)
    end
  end

  def accessory(
        %Enrollment{} = e,
        %{type: "enroll.cancel", attempt: attempt, reason: reason},
        _,
        _,
        _
      ) do
    if attempt == e.attempt and open?(e),
      do: {[], Enrollment.cancel(e, Map.fetch!(@cancel_reasons, reason))},
      else: {[{:ignored, :stale_attempt}], e}
  end

  @doc "The owner, in the app: the codes match, they differ, or cancel."
  @spec owner(
          Enrollment.t(),
          :confirm | :mismatch | :cancel,
          HostKey.t(),
          pos_integer(),
          integer()
        ) ::
          result()
  def owner(%Enrollment{} = e, :confirm, host, gen, now_ms),
    do: e |> Enrollment.owner_confirmed(now_ms) |> then_commit(host, gen)

  def owner(%Enrollment{} = e, :mismatch, _host, gen, now_ms) do
    case Enrollment.mismatch(e, now_ms) do
      {:ok, next} -> {[{:send, Map.delete(Enrollment.begin_message(next, gen), :gen)}], next}
      other -> settled(other)
    end
  end

  def owner(%Enrollment{} = e, :cancel, _host, _gen, _now_ms), do: close(e, :owner)

  @doc "The window's end, read on the link's tick: an open attempt past it is cancelled."
  @spec tick(Enrollment.t(), integer()) :: result()
  def tick(%Enrollment{phase: phase} = e, now_ms) when phase in [:begun, :offered, :revealed] do
    if Enrollment.expired?(e, now_ms), do: close(e, :expired), else: {[], e}
  end

  def tick(%Enrollment{} = e, _now_ms), do: {[], e}

  @doc "The link starts again: an open attempt is cancelled `link_reset`."
  @spec link_reset(Enrollment.t()) :: result()
  def link_reset(%Enrollment{} = e) do
    if open?(e), do: close(e, :link_reset), else: {[], e}
  end

  @doc "What the app shows of the attempt."
  @spec summary(Enrollment.t() | nil) :: map() | nil
  def summary(nil), do: nil

  def summary(%Enrollment{} = e) do
    %{
      attempt: e.attempt,
      round: e.round,
      phase: e.phase,
      code: Enrollment.compare_code(e),
      accessory_confirmed?: e.accessory_confirmed?,
      owner_confirmed?: e.owner_confirmed?,
      closed_reason: e.closed_reason
    }
  end

  defp after_offer({:ok, e}, gen) do
    {:ok, reveal, e} = Enrollment.reveal_message(e, gen)
    {[{:send, Map.delete(reveal, :gen)}], e}
  end

  defp after_offer(other, _gen), do: settled(other)

  defp then_commit({:ok, e}, host, gen) do
    case Enrollment.commit_message(e, host, gen) do
      {:ok, commit, e} -> {[{:send, Map.delete(commit, :gen)}], e}
      {:error, :not_confirmed} -> {[], e}
    end
  end

  defp then_commit(other, _host, _gen), do: settled(other)

  defp settled({:ignored, reason, e}), do: {[{:ignored, reason}], e}
  defp settled({:closed, reason, e}), do: {[cancel_message(e, reason)], e}

  defp close(e, reason) do
    e = Enrollment.cancel(e, reason)
    {[cancel_message(e, reason)], e}
  end

  defp cancel_message(e, reason),
    do: {:send, %{type: "enroll.cancel", attempt: e.attempt, reason: Atom.to_string(reason)}}
end
