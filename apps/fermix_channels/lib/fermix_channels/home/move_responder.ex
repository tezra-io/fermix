defmodule FermixChannels.Home.MoveResponder do
  @moduledoc """
  The candidate's responder for the move (`FXM1 0x04`, Noise `IK`, M75 §7.2):
  its static key is the candidate's own, and the initiator must prove the
  gateway key of the primary the candidate enrolled with, the source of the
  move; any other initiator is closed `1002`.

  Then, in order, each step asked of `FermixChannels.Home.Candidate`:

    * `move_offer` is answered `move_accept {move_id, recipient}` with the
      one-time snapshot recipient the candidate gave at enrollment;
    * `move_chunk`s (from index 0, in order, and no more bytes than the offer
      said) are written to `candidate/incoming.fxsnap` and hashed;
    * `move_end` checks the size and SHA-256 the offer named, and the
      candidate restores the stream in a task; once staged this answers
      `move_ready {move_id, epoch}`;
    * `move_commit` activates the staged home and answers `move_done`, closing
      `1000`; the candidate then restarts as the primary;
    * `move_resume` answers `move_ready` (still staged), `move_done` (the
      home is in place), or `move_failed` while an activation that failed
      part-way is being tried again, so the source keeps resuming.

  A refused step is `error` with `move_unknown`, `move_mismatch` or
  `move_failed` and a sentence, then close `4003 move <code>`. `ping` is
  answered `pong`; any other event, `unsupported_event` (`Mobile.Peers`).

  Options: `:candidate` (the candidate process).
  """

  @behaviour FermixChannels.Home.Responder

  require Logger

  alias FermixChannels.Home.Candidate
  alias FermixChannels.Home.ResponderWire

  @impl true
  def serving?(opts), do: opts |> server() |> Candidate.serving?()

  @impl true
  def init(wire, opts) do
    server = server(opts)

    with {:ok, keys} <- Candidate.keys(server),
         {:ok, reply, session, remote} <-
           ResponderWire.handshake(:ik_move, wire, [static_keypair: keys.noise], :move),
         true <- :crypto.hash_equals(remote, keys.source_pk) do
      {:push, [reply], %{server: server, wire: session, move: nil, io: nil}}
    else
      false -> {:stop, :not_the_source, {1002, "mobile protocol error"}, %{io: nil}}
      {:error, reason} -> {:stop, reason, {1002, "mobile protocol error"}, %{io: nil}}
    end
  end

  @impl true
  def handle_frame(ciphertext, state) do
    case ResponderWire.read(state.wire, ciphertext) do
      {:ok, event, wire} -> handle_event(event, %{state | wire: wire})
      {:refused, type, wire} -> unsupported(type, %{state | wire: wire})
      {:error, reason} -> {:stop, reason, {1002, "mobile protocol error"}, state}
    end
  end

  @impl true
  def handle_info(
        {:candidate_staged, move_id, {:ok, epoch}},
        %{move: %{move_id: move_id}} = state
      ),
      do: send_event("move_ready", %{"move_id" => move_id, "epoch" => epoch}, state)

  def handle_info(
        {:candidate_staged, move_id, {:error, sentence}},
        %{move: %{move_id: move_id}} = state
      ),
      do: refuse("move_failed", sentence, state)

  def handle_info(_message, state), do: {:ok, state}

  @impl true
  def terminate(_reason, state) do
    close_io(state)
    :ok
  end

  @impl true
  def past_handshake?(%{wire: _wire}), do: true
  def past_handshake?(_state), do: false

  # -- events -----------------------------------------------------------------

  defp handle_event(%{type: "move_offer", payload: offer}, state) do
    close_io(state)

    case Candidate.offer(state.server, offer) do
      {:ok, %{recipient: recipient, incoming: path}} ->
        receive_stream(offer, recipient, path, state)

      {:error, code, sentence} ->
        refuse(code, sentence, state)
    end
  end

  defp handle_event(
         %{type: "move_chunk", payload: %{"move_id" => id, "index" => index}, bytes: bytes},
         state
       ) do
    case state.move do
      %{move_id: ^id, next: ^index, io: io} = move -> write_chunk(io, bytes, move, state)
      _other -> refuse("move_mismatch", "That chunk is not the next one of this move.", state)
    end
  end

  defp handle_event(
         %{type: "move_end", payload: %{"move_id" => id}},
         %{move: %{move_id: id, hash: _hash}} = state
       ),
       do: end_stream(state)

  defp handle_event(%{type: "move_commit", payload: %{"move_id" => id}}, state) do
    case Candidate.commit(state.server, id) do
      {:ok, epoch} -> send_and_stop("move_done", %{"move_id" => id, "epoch" => epoch}, state)
      {:error, code, sentence} -> refuse(code, sentence, state)
    end
  end

  defp handle_event(%{type: "move_resume", payload: %{"move_id" => id}}, state) do
    case Candidate.resume(state.server, id) do
      {:staged, epoch} ->
        send_event("move_ready", %{"move_id" => id, "epoch" => epoch}, %{
          state
          | move: %{move_id: id}
        })

      {:activated, epoch} ->
        send_and_stop("move_done", %{"move_id" => id, "epoch" => epoch}, state)

      :activating ->
        refuse("move_failed", "This candidate is still putting the home in place.", state)

      :unknown ->
        refuse("move_unknown", "This candidate holds no move with that id.", state)
    end
  end

  defp handle_event(%{type: "ping"}, state), do: send_event("pong", %{}, state)

  defp handle_event(%{type: type}, state),
    do: refuse("move_mismatch", "#{type} does not belong to the move under way.", state)

  defp receive_stream(offer, recipient, path, state) do
    case File.open(path, [:write, :exclusive, :binary]) do
      {:ok, io} ->
        move = %{
          move_id: offer["move_id"],
          size: offer["size_bytes"],
          sha256: String.downcase(offer["sha256"]),
          next: 0,
          received: 0,
          hash: :crypto.hash_init(:sha256),
          io: io
        }

        send_event("move_accept", %{"move_id" => move.move_id, "recipient" => recipient}, %{
          state
          | move: move,
            io: io
        })

      {:error, reason} ->
        refuse("move_failed", "The candidate could not write the stream (#{reason}).", state)
    end
  end

  defp write_chunk(io, bytes, move, state) do
    received = move.received + byte_size(bytes)

    with true <- received <= move.size,
         :ok <- IO.binwrite(io, bytes) do
      move = %{
        move
        | next: move.next + 1,
          received: received,
          hash: :crypto.hash_update(move.hash, bytes)
      }

      {:ok, %{state | move: move}}
    else
      false ->
        refuse("move_mismatch", "The stream is longer than the offer said.", state)

      {:error, reason} ->
        refuse("move_failed", "The stream could not be written (#{inspect(reason)}).", state)
    end
  end

  defp end_stream(%{move: move} = state) do
    close_io(state)
    state = %{state | io: nil}
    digest = move.hash |> :crypto.hash_final() |> Base.encode16(case: :lower)

    cond do
      move.received != move.size ->
        refuse("move_mismatch", "The stream is shorter than the offer said.", state)

      digest != move.sha256 ->
        refuse("move_mismatch", "The stream's SHA-256 is not the one the offer named.", state)

      true ->
        stage(move, state)
    end
  end

  defp stage(move, state) do
    case Candidate.stage(state.server, move.move_id, self()) do
      :ok -> {:ok, %{state | move: %{move_id: move.move_id}}}
      {:error, code, sentence} -> refuse(code, sentence, state)
    end
  end

  # -- answers ----------------------------------------------------------------

  defp send_event(type, payload, state) do
    case ResponderWire.write(state.wire, type, payload) do
      {:ok, frames, wire} -> {:push, frames, %{state | wire: wire}}
      {:error, reason} -> {:stop, reason, {1002, "mobile protocol error"}, state}
    end
  end

  defp send_and_stop(type, payload, state) do
    case ResponderWire.write(state.wire, type, payload) do
      {:ok, frames, wire} -> {:stop, :moved, {1000, "moved"}, frames, %{state | wire: wire}}
      {:error, reason} -> {:stop, reason, {1002, "mobile protocol error"}, state}
    end
  end

  defp unsupported(type, state) do
    case ResponderWire.error(
           state.wire,
           "unsupported_event",
           "A move session does not take #{type}."
         ) do
      {:ok, frames, wire} -> {:push, frames, %{state | wire: wire}}
      {:error, reason} -> {:stop, reason, {1002, "mobile protocol error"}, state}
    end
  end

  defp refuse(code, sentence, state) do
    Logger.warning("move refused: #{code}: #{sentence}")
    close_io(state)
    state = %{state | io: nil}

    case ResponderWire.error(state.wire, code, sentence) do
      {:ok, frames, wire} ->
        {:stop, {:move, code}, {4003, "move #{code}"}, frames, %{state | wire: wire}}

      {:error, reason} ->
        {:stop, reason, {4003, "move #{code}"}, state}
    end
  end

  defp close_io(%{io: io}) when not is_nil(io), do: File.close(io)
  defp close_io(_state), do: :ok

  defp server(opts), do: Keyword.get(opts, :candidate, Candidate)
end
